//! Exception / Throwable stdlib intrinsics.
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
const ValueList = runtime.ValueList;
const ValueBox = runtime.ObjRef(Value);

fn ok(v: Value) EvalResult {
    return .{ .ok = v };
}

fn typeErr(msg: []const u8) EvalResult {
    return .{ .err = .{ .Type = msg } };
}

// ============================================================
// Exceptions
// ============================================================

/// Build a `Value.Exception` for `fqn` with an optional message. The `fqn`
/// and (when present) `message` slices are copied into fresh refcounted
/// handles allocated from `allocator`. Re-exported for sibling intrinsic
/// modules.
pub fn makeException(allocator: std.mem.Allocator, fqn: []const u8, message: ?[]const u8) std.mem.Allocator.Error!Value {
    return .{ .Exception = .{
        .fqn = try runtime.strInit(allocator, fqn),
        .message = .from(if (message) |m| try runtime.strInit(allocator, m) else null),
        .cause = null,
        // A shared suppressed list so `addSuppressed` (e.g. from `use`'s
        // close-while-failing path) records onto this throwable.
        .suppressed = (try ValueList.init(allocator, .empty)).cell,
    } };
}

/// Throwable accepts up to two arguments:
///   (), (message), (cause), (message, cause).
/// A single Throwable-typed argument is treated as `cause`; anything else
/// becomes `message`.
pub fn buildException(ctx: *CallCtx, fqn: []const u8) std.mem.Allocator.Error!EvalResult {
    var message: ?StringRef = null;
    var cause: ?ValueBox = null;

    const first = if (ctx.args.len > 0) &ctx.args[0] else null;
    const second = if (ctx.args.len > 1) &ctx.args[1] else null;

    if (first) |v| {
        if (second) |c| {
            message = try messageOf(ctx.allocator, v);
            switch (c.*) {
                .Null => cause = null,
                // A builtin exception is `Value.Exception`; a user / pack
                // exception subclass is a `Value.Instance` of a
                // Throwable-derived class. Both are valid causes.
                .Exception, .Instance => {
                    c.retain();
                    cause = try Value.boxRef(ctx.allocator, c.*);
                },
                else => {
                    if (message) |m| freeMessage(ctx.allocator, m);
                    return typeErr("Throwable cause must be a Throwable or null");
                },
            }
        } else {
            if (v.* == .Exception) {
                v.retain();
                cause = try Value.boxRef(ctx.allocator, v.*);
            } else {
                message = try messageOf(ctx.allocator, v);
            }
        }
    }

    return ok(.{ .Exception = .{
        .fqn = try runtime.strInit(ctx.allocator, fqn),
        .message = .from(message),
        .cause = if (cause) |c| c.cell else null,
        .identity = ctx.host.allocInstanceId(),
        // A shared list so `addSuppressed` on any value-copy is observed by
        // `suppressedExceptions` on every other copy of this throwable.
        .suppressed = (try ValueList.init(ctx.allocator, .empty)).cell,
    } });
}

/// `Value::Null => None`, `Value::String(s) => Some(text)`,
/// `other => Some(format!("{other}"))` — rendered into a fresh handle.
fn messageOf(allocator: std.mem.Allocator, v: *const Value) std.mem.Allocator.Error!?StringRef {
    return switch (v.*) {
        .Null => null,
        else => blk: {
            const s = try v.display(allocator);
            break :blk try runtime.strInitOwned(allocator, s);
        },
    };
}

/// Free a message handle built by `messageOf`. The cell owns its bytes and
/// frees them on the last `deinit`. Used on the error path that discards a
/// half-built exception.
fn freeMessage(allocator: std.mem.Allocator, m: StringRef) void {
    _ = allocator;
    m.deinit();
}

pub fn excn_throwable(ctx: *CallCtx) std.mem.Allocator.Error!EvalResult {
    return buildException(ctx, "kotlin.Throwable");
}
pub fn excn_exception(ctx: *CallCtx) std.mem.Allocator.Error!EvalResult {
    return buildException(ctx, "kotlin.Exception");
}
pub fn excn_error(ctx: *CallCtx) std.mem.Allocator.Error!EvalResult {
    return buildException(ctx, "kotlin.Error");
}
pub fn excn_runtime(ctx: *CallCtx) std.mem.Allocator.Error!EvalResult {
    return buildException(ctx, "kotlin.RuntimeException");
}
pub fn excn_illegal_argument(ctx: *CallCtx) std.mem.Allocator.Error!EvalResult {
    return buildException(ctx, "kotlin.IllegalArgumentException");
}
pub fn excn_illegal_state(ctx: *CallCtx) std.mem.Allocator.Error!EvalResult {
    return buildException(ctx, "kotlin.IllegalStateException");
}
pub fn excn_npe(ctx: *CallCtx) std.mem.Allocator.Error!EvalResult {
    return buildException(ctx, "kotlin.NullPointerException");
}
pub fn excn_ioob(ctx: *CallCtx) std.mem.Allocator.Error!EvalResult {
    return buildException(ctx, "kotlin.IndexOutOfBoundsException");
}
pub fn excn_arithmetic(ctx: *CallCtx) std.mem.Allocator.Error!EvalResult {
    return buildException(ctx, "kotlin.ArithmeticException");
}
pub fn excn_class_cast(ctx: *CallCtx) std.mem.Allocator.Error!EvalResult {
    return buildException(ctx, "kotlin.ClassCastException");
}
pub fn excn_no_such_element(ctx: *CallCtx) std.mem.Allocator.Error!EvalResult {
    return buildException(ctx, "kotlin.NoSuchElementException");
}
pub fn excn_unsupported(ctx: *CallCtx) std.mem.Allocator.Error!EvalResult {
    return buildException(ctx, "kotlin.UnsupportedOperationException");
}
pub fn excn_uninitialized(ctx: *CallCtx) std.mem.Allocator.Error!EvalResult {
    return buildException(ctx, "kotlin.UninitializedPropertyAccessException");
}
pub fn excn_cancellation(ctx: *CallCtx) std.mem.Allocator.Error!EvalResult {
    const a = ctx.allocator;
    const fqn = "kotlin.coroutines.cancellation.CancellationException";
    // `CancellationException(cause)` — a single Throwable argument — defaults
    // its message to cause.toString(); the generic builder leaves it null.
    if (ctx.args.len == 1 and (ctx.args[0] == .Exception or ctx.args[0] == .Instance)) {
        const cause = ctx.args[0];
        var message: ?StringRef = null;
        if (try ctx.host.invokeMethod(&cause, "toString", &.{}, ctx.out)) |m| {
            if (m == .ok and m.ok == .String) {
                const g = m.ok.String.borrow();
                defer g.deinit();
                message = try runtime.strInit(a, g.get().bytes);
            }
        }
        cause.retain();
        const cbox = try Value.boxRef(a, cause);
        return ok(.{ .Exception = .{
            .fqn = try runtime.strInit(a, fqn),
            .message = .from(message),
            .cause = cbox.cell,
            .identity = ctx.host.allocInstanceId(),
            .suppressed = (try ValueList.init(a, .empty)).cell,
        } });
    }
    return buildException(ctx, fqn);
}
pub fn excn_no_when(ctx: *CallCtx) std.mem.Allocator.Error!EvalResult {
    return buildException(ctx, "kotlin.NoWhenBranchMatchedException");
}
pub fn excn_number_format(ctx: *CallCtx) std.mem.Allocator.Error!EvalResult {
    return buildException(ctx, "kotlin.NumberFormatException");
}
pub fn excn_concurrent_mod(ctx: *CallCtx) std.mem.Allocator.Error!EvalResult {
    return buildException(ctx, "kotlin.ConcurrentModificationException");
}
pub fn excn_assertion_error(ctx: *CallCtx) std.mem.Allocator.Error!EvalResult {
    return buildException(ctx, "kotlin.AssertionError");
}

pub fn throwable_message(ctx: *CallCtx) std.mem.Allocator.Error!EvalResult {
    if (ctx.args.len == 0 or ctx.args[0] != .Exception) {
        return typeErr("message requires a Throwable receiver");
    }
    const message = ctx.args[0].Exception.message;
    if (message.get()) |m| {
        return ok(.{ .String = m.clone() });
    }
    return ok(.Null);
}

pub fn throwable_to_string(ctx: *CallCtx) std.mem.Allocator.Error!EvalResult {
    if (ctx.args.len == 0 or ctx.args[0] != .Exception) {
        return typeErr("toString requires a Throwable receiver");
    }
    const s = try ctx.args[0].display(ctx.allocator);
    return ok(.{ .String = try runtime.strInitOwned(ctx.allocator, s) });
}

/// `Throwable.addSuppressed(other)` — append to the receiver's shared
/// suppressed list (built at construction). A throwable created outside the
/// constructor path has no list, so the call is a no-op there.
pub fn throwable_add_suppressed(ctx: *CallCtx) std.mem.Allocator.Error!EvalResult {
    if (ctx.args.len >= 2 and ctx.args[0] == .Exception) {
        if (ctx.args[0].Exception.suppressed) |sl_cell| {
            const sl = ValueList{ .cell = sl_cell };
            const g = sl.borrowMut();
            defer g.deinit();
            if (runtime.reclaimEnabled()) ctx.args[1].retain();
            try g.get().append(ctx.allocator, ctx.args[1]);
        }
    }
    // A USER throwable is an interpreted Instance; its suppressed set is
    // the hidden `__suppressed__` list the member arms also maintain. The
    // statically bound header call lands here directly, so the Instance
    // shape must be served, not silently dropped.
    if (ctx.args.len >= 2 and ctx.args[0] == .Instance) {
        const inst = ctx.args[0].Instance;
        const existing: ?Value = blk: {
            const g = inst.borrow();
            defer g.deinit();
            break :blk g.get().get("__suppressed__");
        };
        const list: Value = blk: {
            if (existing) |l| {
                if (l == .List) break :blk l;
            }
            const items = try ValueList.init(ctx.allocator, .empty);
            const fresh = Value{ .List = .{ .items = items, .mutable = true, .enum_entries = false, .backing = null } };
            const g = inst.borrowMut();
            defer g.deinit();
            try g.get().define(ctx.allocator, "__suppressed__", fresh);
            break :blk fresh;
        };
        const g = list.List.items.borrowMut();
        defer g.deinit();
        if (runtime.reclaimEnabled()) ctx.args[1].retain();
        try g.get().append(ctx.allocator, ctx.args[1]);
    }
    return ok(.Unit);
}

/// `Throwable.suppressedExceptions` / `getSuppressed()` — a read-only view of
/// the receiver's shared suppressed list (empty when none recorded).
pub fn throwable_suppressed(ctx: *CallCtx) std.mem.Allocator.Error!EvalResult {
    if (ctx.args.len >= 1 and ctx.args[0] == .Exception) {
        if (ctx.args[0].Exception.suppressed) |sl_cell| {
            return ok(makeList((ValueList{ .cell = sl_cell }).clone(), false));
        }
    }
    if (ctx.args.len >= 1 and ctx.args[0] == .Instance) {
        const inst = ctx.args[0].Instance;
        const g = inst.borrow();
        defer g.deinit();
        if (g.get().get("__suppressed__")) |l| {
            if (l == .List) return ok(makeList(l.List.items.clone(), false));
        }
    }
    const items = try ValueList.init(ctx.allocator, .empty);
    return ok(makeList(items, false));
}

pub fn throwable_cause(ctx: *CallCtx) std.mem.Allocator.Error!EvalResult {
    if (ctx.args.len == 0 or ctx.args[0] != .Exception) {
        return typeErr("cause requires a Throwable receiver");
    }
    const cause = ctx.args[0].Exception.cause;
    if (cause) |c| {
        const out = (ValueBox{ .cell = c }).asPtr().*;
        out.retain();
        return ok(out);
    }
    return ok(.Null);
}

fn makeList(items: ValueList, mutable: bool) Value {
    return .{ .List = .{
        .items = items,
        .mutable = mutable,
        .enum_entries = false,
        .backing = null,
    } };
}

// ============================================================
// Tests
// ============================================================

const testing = std.testing;

// A shared stateless host so the exception constructor's
// `ctx.host.allocInstanceId()` resolves (NoopHost has no `alloc_instance_id`
// vtable entry, so it returns 0) instead of dereferencing an undefined host.
var test_noop_host: runtime.NoopHost = .{};

fn noopCtx(args: []const Value) CallCtx {
    return .{
        .args = args,
        .out = undefined,
        .host = test_noop_host.host(),
        .allocator = testing.allocator,
    };
}

fn freeException(exc: anytype) void {
    exc.fqn.deinit();
    if (exc.message.get()) |m| m.deinit();
    if (exc.cause) |c| (ValueBox{ .cell = c }).deinit();
    if (exc.suppressed) |s| (ValueList{ .cell = s }).deinit();
}

/// Free the handles a `makeException` result owns in a test — its `fqn`,
/// optional `message`, and the eagerly-allocated `suppressed` list.
fn freeMade(v: Value) void {
    v.Exception.fqn.deinit();
    if (v.Exception.message.get()) |m| m.deinit();
    if (v.Exception.suppressed) |s| (ValueList{ .cell = s }).deinit();
}

test "build exception with no arguments" {
    var ctx = noopCtx(&.{});
    const r = try excn_illegal_state(&ctx);
    try testing.expect(r == .ok);
    const exc = r.ok.Exception;
    defer freeException(exc);
    const fg = exc.fqn.borrow();
    defer fg.deinit();
    try testing.expectEqualStrings("kotlin.IllegalStateException", fg.get().bytes);
    try testing.expect(!exc.message.isSome());
    try testing.expect(exc.cause == null);
}

test "single string argument becomes the message" {
    const msg = try runtime.strInit(testing.allocator, "boom");
    defer msg.deinit();
    const args = [_]Value{.{ .String = msg }};
    var ctx = noopCtx(&args);
    const r = try excn_illegal_argument(&ctx);
    try testing.expect(r == .ok);
    const exc = r.ok.Exception;
    defer freeException(exc);
    const fg = exc.fqn.borrow();
    defer fg.deinit();
    try testing.expectEqualStrings("kotlin.IllegalArgumentException", fg.get().bytes);
    const mg = exc.message.get().?.borrow();
    defer mg.deinit();
    try testing.expectEqualStrings("boom", mg.get().bytes);
    try testing.expect(exc.cause == null);
}

test "single null argument leaves the message empty" {
    const args = [_]Value{.Null};
    var ctx = noopCtx(&args);
    const r = try excn_exception(&ctx);
    try testing.expect(r == .ok);
    const exc = r.ok.Exception;
    defer freeException(exc);
    try testing.expect(!exc.message.isSome());
    try testing.expect(exc.cause == null);
}

test "single non-string argument is rendered into the message" {
    const args = [_]Value{.{ .Int = 42 }};
    var ctx = noopCtx(&args);
    const r = try excn_runtime(&ctx);
    try testing.expect(r == .ok);
    const exc = r.ok.Exception;
    defer freeException(exc);
    const mg = exc.message.get().?.borrow();
    defer mg.deinit();
    try testing.expectEqualStrings("42", mg.get().bytes);
}

test "single throwable argument is treated as the cause" {
    const inner = try makeException(testing.allocator, "kotlin.IllegalStateException", "inner");
    defer freeMade(inner);
    const args = [_]Value{inner};
    var ctx = noopCtx(&args);
    const r = try excn_runtime(&ctx);
    try testing.expect(r == .ok);
    const exc = r.ok.Exception;
    defer freeException(exc);
    try testing.expect(!exc.message.isSome());
    try testing.expect(exc.cause != null);
    const cause_box = ValueBox{ .cell = exc.cause.? };
    try testing.expect(cause_box.asPtr().* == .Exception);
    const ig = cause_box.asPtr().Exception.fqn.borrow();
    defer ig.deinit();
    try testing.expectEqualStrings("kotlin.IllegalStateException", ig.get().bytes);
}

test "message and cause arguments" {
    const cause = try makeException(testing.allocator, "kotlin.Throwable", null);
    defer freeMade(cause);
    const msg = try runtime.strInit(testing.allocator, "outer");
    defer msg.deinit();
    const args = [_]Value{ .{ .String = msg }, cause };
    var ctx = noopCtx(&args);
    const r = try excn_error(&ctx);
    try testing.expect(r == .ok);
    const exc = r.ok.Exception;
    defer freeException(exc);
    const mg = exc.message.get().?.borrow();
    defer mg.deinit();
    try testing.expectEqualStrings("outer", mg.get().bytes);
    try testing.expect(exc.cause != null);
}

test "non-throwable cause argument is rejected" {
    const msg = try runtime.strInit(testing.allocator, "outer");
    defer msg.deinit();
    const args = [_]Value{ .{ .String = msg }, .{ .Int = 7 } };
    var ctx = noopCtx(&args);
    const r = try excn_error(&ctx);
    try testing.expect(r == .err);
    try testing.expect(r.err == .Type);
}

test "null cause argument is accepted as no cause" {
    const msg = try runtime.strInit(testing.allocator, "outer");
    defer msg.deinit();
    const args = [_]Value{ .{ .String = msg }, .Null };
    var ctx = noopCtx(&args);
    const r = try excn_error(&ctx);
    try testing.expect(r == .ok);
    const exc = r.ok.Exception;
    defer freeException(exc);
    try testing.expect(exc.cause == null);
}

test "instance cause argument is accepted" {
    // A Throwable-derived user subclass shows up as a Value.Instance and is a
    // valid cause; build one through the class machinery is heavyweight here,
    // so exercise the acceptance path via the same branch using an Exception
    // and confirm the dedicated Instance branch compiles by type.
    const cause = try makeException(testing.allocator, "kotlin.RuntimeException", null);
    defer freeMade(cause);
    const msg = try runtime.strInit(testing.allocator, "m");
    defer msg.deinit();
    const args = [_]Value{ .{ .String = msg }, cause };
    var ctx = noopCtx(&args);
    const r = try excn_throwable(&ctx);
    try testing.expect(r == .ok);
    const exc = r.ok.Exception;
    defer freeException(exc);
    try testing.expect(exc.cause != null);
}

test "throwable message accessor returns the message" {
    const inner = try makeException(testing.allocator, "kotlin.Exception", "hi");
    defer freeMade(inner);
    const args = [_]Value{inner};
    var ctx = noopCtx(&args);
    const r = try throwable_message(&ctx);
    try testing.expect(r == .ok);
    try testing.expect(r.ok == .String);
    const g = r.ok.String.borrow();
    defer {
        g.deinit();
        r.ok.String.deinit();
    }
    try testing.expectEqualStrings("hi", g.get().bytes);
}

test "throwable message accessor yields null when absent" {
    const inner = try makeException(testing.allocator, "kotlin.Exception", null);
    defer freeMade(inner);
    const args = [_]Value{inner};
    var ctx = noopCtx(&args);
    const r = try throwable_message(&ctx);
    try testing.expect(r == .ok);
    try testing.expect(r.ok == .Null);
}

test "throwable message rejects a non-throwable receiver" {
    const args = [_]Value{.{ .Int = 1 }};
    var ctx = noopCtx(&args);
    const r = try throwable_message(&ctx);
    try testing.expect(r == .err);
    try testing.expect(r.err == .Type);
}

test "throwable toString renders fqn and message" {
    const inner = try makeException(testing.allocator, "kotlin.IllegalStateException", "bad");
    defer freeMade(inner);
    const args = [_]Value{inner};
    var ctx = noopCtx(&args);
    const r = try throwable_to_string(&ctx);
    try testing.expect(r == .ok);
    const g = r.ok.String.borrow();
    defer {
        g.deinit();
        r.ok.String.deinit();
    }
    try testing.expectEqualStrings("kotlin.IllegalStateException: bad", g.get().bytes);
}

test "throwable toString renders fqn alone when message is absent" {
    const inner = try makeException(testing.allocator, "kotlin.Throwable", null);
    defer freeMade(inner);
    const args = [_]Value{inner};
    var ctx = noopCtx(&args);
    const r = try throwable_to_string(&ctx);
    try testing.expect(r == .ok);
    const g = r.ok.String.borrow();
    defer {
        g.deinit();
        r.ok.String.deinit();
    }
    try testing.expectEqualStrings("kotlin.Throwable", g.get().bytes);
}

test "addSuppressed records nothing and returns Unit" {
    const inner = try makeException(testing.allocator, "kotlin.Throwable", null);
    defer freeMade(inner);
    const args = [_]Value{inner};
    var ctx = noopCtx(&args);
    const r = try throwable_add_suppressed(&ctx);
    try testing.expect(r == .ok);
    try testing.expect(r.ok == .Unit);
}

test "suppressed returns an empty list" {
    var ctx = noopCtx(&.{});
    const r = try throwable_suppressed(&ctx);
    try testing.expect(r == .ok);
    try testing.expect(r.ok == .List);
    // The ObjRef's last `deinit` frees the inner ArrayList.
    defer r.ok.List.items.deinit();
    const g = r.ok.List.items.borrow();
    defer g.deinit();
    try testing.expectEqual(@as(usize, 0), g.get().items.len);
    try testing.expect(!r.ok.List.mutable);
}

test "cause accessor returns the cause value" {
    const cause = try makeException(testing.allocator, "kotlin.IllegalStateException", null);
    const cause_box = try Value.boxRef(testing.allocator, cause);
    const outer = Value{ .Exception = .{
        .fqn = try runtime.strInit(testing.allocator, "kotlin.RuntimeException"),
        .message = .{},
        .cause = cause_box.cell,
    } };
    defer {
        outer.Exception.fqn.deinit();
        (ValueBox{ .cell = outer.Exception.cause.? }).deinit();
    }
    const args = [_]Value{outer};
    var ctx = noopCtx(&args);
    const r = try throwable_cause(&ctx);
    try testing.expect(r == .ok);
    try testing.expect(r.ok == .Exception);
    defer r.ok.release(testing.allocator);
    const g = r.ok.Exception.fqn.borrow();
    defer g.deinit();
    try testing.expectEqualStrings("kotlin.IllegalStateException", g.get().bytes);
}

test "cause accessor yields null when absent" {
    const inner = try makeException(testing.allocator, "kotlin.Throwable", null);
    defer freeMade(inner);
    const args = [_]Value{inner};
    var ctx = noopCtx(&args);
    const r = try throwable_cause(&ctx);
    try testing.expect(r == .ok);
    try testing.expect(r.ok == .Null);
}

test "cause accessor rejects a non-throwable receiver" {
    const args = [_]Value{.{ .Bool = true }};
    var ctx = noopCtx(&args);
    const r = try throwable_cause(&ctx);
    try testing.expect(r == .err);
    try testing.expect(r.err == .Type);
}

test "make exception copies fqn and message into fresh handles" {
    const exc = try makeException(testing.allocator, "kotlin.Error", "oops");
    defer freeMade(exc);
    const fg = exc.Exception.fqn.borrow();
    defer fg.deinit();
    try testing.expectEqualStrings("kotlin.Error", fg.get().bytes);
    const mg = exc.Exception.message.get().?.borrow();
    defer mg.deinit();
    try testing.expectEqualStrings("oops", mg.get().bytes);
}
