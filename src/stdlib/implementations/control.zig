//! Control-flow / builder / contract stdlib intrinsics.
//!

const std = @import("std");
const stringbuilder_impl = @import("stringbuilder.zig");
const runtime = @import("runtime");
const collections = @import("collections.zig");

const Value = runtime.Value;
const RuntimeError = runtime.RuntimeError;
const EvalResult = runtime.EvalResult;
const CallCtx = runtime.CallCtx;
const StringRef = runtime.StringRef;
const ValueList = runtime.ValueList;
const MapEntries = runtime.MapEntries;
const ObjRef = runtime.ObjRef;

fn ok(v: Value) EvalResult {
    return .{ .ok = v };
}

fn arityErr(msg: []const u8) EvalResult {
    return .{ .err = .{ .Arity = msg } };
}

/// An explicit negative capacity throws `IllegalArgumentException` before the
/// builder block runs. Null when the capacity is absent or valid.
fn negativeCapacity(ctx: *CallCtx) std.mem.Allocator.Error!?EvalResult {
    if (ctx.args.len < 2) return null;
    const cap = ctx.args[0].asI64() orelse return null;
    if (cap >= 0) return null;
    const msg = try std.fmt.allocPrint(ctx.allocator, "capacity must be non-negative, but was {d}.", .{cap});
    return EvalResult{ .err = .{ .Thrown = try Value.newException(ctx.allocator, .{
        .fqn = try runtime.strInit(ctx.allocator, "kotlin.IllegalArgumentException"),
        .message = .from(try runtime.strInitOwned(ctx.allocator, msg)),
        .cause = null,
        .suppressed = (try runtime.ValueList.init(ctx.allocator, .empty)).cell,
    }) } };
}

pub fn builders_build_list(ctx: *CallCtx) std.mem.Allocator.Error!EvalResult {
    if (ctx.args.len == 0 or ctx.args.len > 2) {
        return arityErr("buildList expects (block) or (capacity, block)");
    }
    if (try negativeCapacity(ctx)) |e| return e;
    const block = ctx.args[ctx.args.len - 1];
    const buildable = try Value.newList(ctx.allocator, .{
        .items = try ValueList.init(ctx.allocator, .empty),
        .mutable = true,
        .enum_entries = false,
        .backing = null,
        .mod_count = .from(try ObjRef(u64).init(ctx.allocator, 0)),
    });
    {
        const r = try ctx.host.invokeCallableWithThis(&block, &.{}, &buildable, ctx.out);
        if (r == .err) {
            buildable.release(ctx.allocator);
            return r;
        }
    }
    if (buildable.List.mod_count.get()) |mc| {
        const g = mc.borrowMut();
        g.get().* |= collections.FROZEN_MOD_BIT;
        g.deinit();
    }
    // An empty build result is the shared empty singleton, as Kotlin's
    // `buildList` returns EmptyList for size 0.
    const list_empty = blk: {
        const g = buildable.List.items.borrow();
        defer g.deinit();
        break :blk g.get().items.len == 0;
    };
    if (list_empty) {
        buildable.release(ctx.allocator);
        return ok(try collections.sharedEmptyList(ctx.allocator));
    }
    buildable.List.mutable = false;
    return ok(buildable);
}

/// Flip an already-built list read-only in place: the frozen counter rejects
/// mutation through every leaked view, and an empty result collapses to the
/// shared empty singleton.
pub fn builders_freeze_list(ctx: *CallCtx) std.mem.Allocator.Error!EvalResult {
    if (ctx.args.len != 1 or ctx.args[0] != .List) {
        return .{ .err = .{ .Type = "__klio_freezeList expects a List" } };
    }
    var buildable = ctx.args[0];
    if (buildable.List.mod_count.get()) |mc| {
        const g = mc.borrowMut();
        g.get().* |= collections.FROZEN_MOD_BIT;
        g.deinit();
    }
    const list_empty = blk: {
        const g = buildable.List.items.borrow();
        defer g.deinit();
        break :blk g.get().items.len == 0;
    };
    if (list_empty) {
        return ok(try collections.sharedEmptyList(ctx.allocator));
    }
    buildable.retain();
    buildable.List.mutable = false;
    return ok(buildable);
}

pub fn builders_freeze_set(ctx: *CallCtx) std.mem.Allocator.Error!EvalResult {
    if (ctx.args.len != 1 or ctx.args[0] != .Set) {
        return .{ .err = .{ .Type = "__klio_freezeSet expects a Set" } };
    }
    var buildable = ctx.args[0];
    if (buildable.Set.mod_count.get()) |mc| {
        const g = mc.borrowMut();
        g.get().* |= collections.FROZEN_MOD_BIT;
        g.deinit();
    }
    const set_empty = blk: {
        const g = buildable.Set.items.borrow();
        defer g.deinit();
        break :blk g.get().items.len == 0;
    };
    if (set_empty) {
        return ok(try collections.sharedEmptySet(ctx.allocator));
    }
    buildable.retain();
    buildable.Set.mutable = false;
    return ok(buildable);
}

pub fn builders_freeze_map(ctx: *CallCtx) std.mem.Allocator.Error!EvalResult {
    if (ctx.args.len != 1 or ctx.args[0] != .Map) {
        return .{ .err = .{ .Type = "__klio_freezeMap expects a Map" } };
    }
    var buildable = ctx.args[0];
    {
        const g = buildable.Map.entries.borrow();
        const mc = g.get().mod_count;
        g.deinit();
        if (mc.get()) |cell| {
            const cg = cell.borrowMut();
            cg.get().* |= collections.FROZEN_MOD_BIT;
            cg.deinit();
        }
    }
    const map_empty = blk: {
        const g = buildable.Map.entries.borrow();
        defer g.deinit();
        break :blk g.get().pairs.items.len == 0;
    };
    if (map_empty) {
        return ok(try collections.sharedEmptyMap(ctx.allocator));
    }
    buildable.retain();
    buildable.Map.mutable = false;
    return ok(buildable);
}

pub fn builders_build_set(ctx: *CallCtx) std.mem.Allocator.Error!EvalResult {
    if (ctx.args.len == 0 or ctx.args.len > 2) {
        return arityErr("buildSet expects (block) or (capacity, block)");
    }
    if (try negativeCapacity(ctx)) |e| return e;
    const block = ctx.args[ctx.args.len - 1];
    // A genuine mutable Set builder: `add` dedupes under the block, so a builder
    // iterator sees `add(existing)` as a no-op.
    const buildable = try Value.newSet(ctx.allocator, .{
        .items = try ValueList.init(ctx.allocator, .empty),
        .mutable = true,
        .backing = null,
        .mod_count = .from(try ObjRef(u64).init(ctx.allocator, 0)),
    });
    {
        const r = try ctx.host.invokeCallableWithThis(&block, &.{}, &buildable, ctx.out);
        if (r == .err) {
            buildable.release(ctx.allocator);
            return r;
        }
    }
    if (buildable.Set.mod_count.get()) |mc| {
        const g = mc.borrowMut();
        g.get().* |= collections.FROZEN_MOD_BIT;
        g.deinit();
    }
    const set_empty = blk: {
        const g = buildable.Set.items.borrow();
        defer g.deinit();
        break :blk g.get().items.len == 0;
    };
    if (set_empty) {
        buildable.release(ctx.allocator);
        return ok(try collections.sharedEmptySet(ctx.allocator));
    }
    buildable.Set.mutable = false;
    return ok(buildable);
}

pub fn builders_build_map(ctx: *CallCtx) std.mem.Allocator.Error!EvalResult {
    if (ctx.args.len == 0 or ctx.args.len > 2) {
        return arityErr("buildMap expects (block) or (capacity, block)");
    }
    if (try negativeCapacity(ctx)) |e| return e;
    const block = ctx.args[ctx.args.len - 1];
    const buildable = try Value.newMap(ctx.allocator, .{
        .entries = try MapEntries.init(ctx.allocator, .{ .mod_count = .from(try ObjRef(u64).init(ctx.allocator, 0)) }),
        .mutable = true,
    });
    {
        const r = try ctx.host.invokeCallableWithThis(&block, &.{}, &buildable, ctx.out);
        if (r == .err) {
            buildable.release(ctx.allocator);
            return r;
        }
    }
    {
        const g = buildable.Map.entries.borrow();
        const mc = g.get().mod_count;
        g.deinit();
        if (mc.get()) |cell| {
            const cg = cell.borrowMut();
            cg.get().* |= collections.FROZEN_MOD_BIT;
            cg.deinit();
        }
    }
    const map_empty = blk: {
        const g = buildable.Map.entries.borrow();
        defer g.deinit();
        break :blk g.get().pairs.items.len == 0;
    };
    if (map_empty) {
        buildable.release(ctx.allocator);
        return ok(try collections.sharedEmptyMap(ctx.allocator));
    }
    buildable.Map.mutable = false;
    return ok(buildable);
}

pub fn builders_build_string(ctx: *CallCtx) std.mem.Allocator.Error!EvalResult {
    // The capacity is only a sizing hint here, so the builder lambda is always
    // the last argument.
    const block = switch (ctx.args.len) {
        1 => ctx.args[0],
        2 => ctx.args[1],
        else => return arityErr("buildString expects (block) or (capacity, block)"),
    };
    const sb = Value{ .StringBuilder = try ObjRef(std.ArrayList(u8)).init(ctx.allocator, .empty) };
    stringbuilder_impl.sbMemoInvalidate(@intFromPtr(sb.StringBuilder.cell));
    {
        const r = try ctx.host.invokeCallableWithThis(&block, &.{}, &sb, ctx.out);
        if (r == .err) {
            sb.StringBuilder.deinit();
            return r;
        }
    }
    const owned = blk: {
        const g = sb.StringBuilder.borrow();
        defer g.deinit();
        break :blk try ctx.allocator.dupe(u8, g.get().items);
    };
    sb.StringBuilder.deinit();
    return ok(.{ .String = try runtime.strInitOwned(ctx.allocator, owned) });
}

pub fn contract_error(ctx: *CallCtx) std.mem.Allocator.Error!EvalResult {
    const v = if (ctx.args.len > 0) ctx.args[0] else Value.Null;
    const msg = switch (v) {
        .String => |s| blk: {
            const g = s.borrow();
            defer g.deinit();
            break :blk try ctx.allocator.dupe(u8, g.get().bytes);
        },
        else => try v.display(ctx.allocator),
    };
    return .{ .err = .{ .Thrown = try Value.newException(ctx.allocator, .{
        .fqn = try runtime.strInit(ctx.allocator, "kotlin.IllegalStateException"),
        .message = .from(try runtime.strInitOwned(ctx.allocator, msg)),
        .cause = null,
        .suppressed = (try runtime.ValueList.init(ctx.allocator, .empty)).cell,
    }) } };
}

pub fn contract_todo(ctx: *CallCtx) std.mem.Allocator.Error!EvalResult {
    const msg = if (ctx.args.len > 0) switch (ctx.args[0]) {
        .String => |s| blk: {
            const g = s.borrow();
            defer g.deinit();
            break :blk try std.fmt.allocPrint(ctx.allocator, "An operation is not implemented: {s}", .{g.get().bytes});
        },
        else => blk: {
            const rendered = try ctx.args[0].display(ctx.allocator);
            defer ctx.allocator.free(rendered);
            break :blk try std.fmt.allocPrint(ctx.allocator, "An operation is not implemented: {s}", .{rendered});
        },
    } else try ctx.allocator.dupe(u8, "An operation is not implemented.");
    return .{ .err = .{ .Thrown = try Value.newException(ctx.allocator, .{
        .fqn = try runtime.strInit(ctx.allocator, "kotlin.NotImplementedError"),
        .message = .from(try runtime.strInitOwned(ctx.allocator, msg)),
        .cause = null,
        .suppressed = (try runtime.ValueList.init(ctx.allocator, .empty)).cell,
    }) } };
}

const testing = std.testing;

const RecordingHost = struct {
    append_values: []const Value = &.{},
    append_bytes: []const u8 = "",
    append_entries: []const runtime.MapPair = &.{},
    fail_with: ?RuntimeError = null,
    allocator: std.mem.Allocator,
    invoked: usize = 0,

    fn init(allocator: std.mem.Allocator) RecordingHost {
        return .{ .allocator = allocator };
    }
    fn deinit(self: *RecordingHost) void {
        _ = self;
    }

    fn vtInvokeCallable(ctx: *anyopaque, callable: *const Value, args: []const Value, out: runtime.Output) std.mem.Allocator.Error!EvalResult {
        _ = ctx;
        _ = callable;
        _ = args;
        _ = out;
        return .{ .ok = .Unit };
    }
    fn vtInvokeCallableWithThis(ctx: *anyopaque, callable: *const Value, args: []const Value, this_value: *const Value, out: runtime.Output) std.mem.Allocator.Error!EvalResult {
        _ = callable;
        _ = args;
        _ = out;
        const self: *RecordingHost = @ptrCast(@alignCast(ctx));
        self.invoked += 1;
        if (self.fail_with) |e| return .{ .err = e };
        switch (this_value.*) {
            .List => |l| {
                const g = l.items.borrowMut();
                defer g.deinit();
                for (self.append_values) |v| try g.get().append(self.allocator, v);
            },
            .Set => |s| {
                const g = s.items.borrowMut();
                defer g.deinit();
                for (self.append_values) |v| {
                    var dup = false;
                    for (g.get().items) |*existing| {
                        if (Value.structuralEqBoxed(existing, &v)) {
                            dup = true;
                            break;
                        }
                    }
                    if (!dup) try g.get().append(self.allocator, v);
                }
            },
            .Map => |m| {
                const g = m.entries.borrowMut();
                defer g.deinit();
                for (self.append_entries) |e| {
                    try g.get().pairs.append(self.allocator, e);
                    try g.get().noteAppended(self.allocator, g.get().pairs.items.len - 1);
                }
            },
            .StringBuilder => |sb| {
                stringbuilder_impl.sbMemoInvalidate(@intFromPtr(sb.cell));
                const g = sb.borrowMut();
                defer g.deinit();
                try g.get().appendSlice(self.allocator, self.append_bytes);
            },
            else => {},
        }
        return .{ .ok = .Unit };
    }

    const vtable: runtime.IntrinsicHost.VTable = .{
        .invoke_callable = vtInvokeCallable,
        .invoke_callable_with_this = vtInvokeCallableWithThis,
    };

    fn host(self: *RecordingHost) runtime.IntrinsicHost {
        return .{ .ctx = self, .vtable = &vtable };
    }
};

fn freeListResult(v: Value) void {
    // The storage is an `ObjRef` over an `ArrayList`, so releasing the final
    // handle runs the list's own `deinit`; a boxed payload drops its box.
    switch (v) {
        .List => |l| runtime.listRefOf(l).deinit(),
        .Set => |s| runtime.setRefOf(s).deinit(),
        .Map => |m| runtime.mapRefOf(m).deinit(),
        else => {},
    }
}

fn freeException(e: anytype) void {
    runtime.exceptionRefOf(e).deinit();
}

test "buildList freezes a populated list" {
    var rec = RecordingHost.init(testing.allocator);
    defer rec.deinit();
    const appended = [_]Value{ .{ .Int = 1 }, .{ .Int = 2 } };
    rec.append_values = &appended;
    var cap = runtime.CaptureOutput.init(testing.allocator);
    defer cap.deinit();
    const block: Value = .Unit;
    const args = [_]Value{block};
    var ctx = CallCtx{ .args = &args, .out = cap.output(), .host = rec.host(), .allocator = testing.allocator };
    const r = try builders_build_list(&ctx);
    try testing.expect(r == .ok);
    defer freeListResult(r.ok);
    try testing.expect(!r.ok.List.mutable);
    const g = r.ok.List.items.borrow();
    defer g.deinit();
    try testing.expectEqual(@as(usize, 2), g.get().items.len);
    try testing.expectEqual(@as(i32, 1), g.get().items[0].Int);
    try testing.expectEqual(@as(i32, 2), g.get().items[1].Int);
}

test "buildList accepts a capacity hint argument" {
    var rec = RecordingHost.init(testing.allocator);
    defer rec.deinit();
    var cap = runtime.CaptureOutput.init(testing.allocator);
    defer cap.deinit();
    const args = [_]Value{ .{ .Int = 8 }, .Unit };
    var ctx = CallCtx{ .args = &args, .out = cap.output(), .host = rec.host(), .allocator = testing.allocator };
    const r = try builders_build_list(&ctx);
    try testing.expect(r == .ok);
    defer freeListResult(r.ok);
    try testing.expectEqual(@as(usize, 1), rec.invoked);
}

test "buildList rejects bad arity" {
    var rec = RecordingHost.init(testing.allocator);
    defer rec.deinit();
    var cap = runtime.CaptureOutput.init(testing.allocator);
    defer cap.deinit();
    var ctx = CallCtx{ .args = &.{}, .out = cap.output(), .host = rec.host(), .allocator = testing.allocator };
    const r = try builders_build_list(&ctx);
    try testing.expect(r == .err);
    try testing.expect(r.err == .Arity);
}

test "buildSet dedups structurally equal elements" {
    var rec = RecordingHost.init(testing.allocator);
    defer rec.deinit();
    const appended = [_]Value{ .{ .Int = 1 }, .{ .Int = 1 }, .{ .Int = 2 } };
    rec.append_values = &appended;
    var cap = runtime.CaptureOutput.init(testing.allocator);
    defer cap.deinit();
    const args = [_]Value{.Unit};
    var ctx = CallCtx{ .args = &args, .out = cap.output(), .host = rec.host(), .allocator = testing.allocator };
    const r = try builders_build_set(&ctx);
    try testing.expect(r == .ok);
    defer freeListResult(r.ok);
    try testing.expect(r.ok == .Set);
    try testing.expect(!r.ok.Set.mutable);
    const g = r.ok.Set.items.borrow();
    defer g.deinit();
    try testing.expectEqual(@as(usize, 2), g.get().items.len);
    try testing.expectEqual(@as(i32, 1), g.get().items[0].Int);
    try testing.expectEqual(@as(i32, 2), g.get().items[1].Int);
}

test "buildMap freezes the produced entries" {
    var rec = RecordingHost.init(testing.allocator);
    defer rec.deinit();
    const entries = [_]runtime.MapPair{
        .{ .key = .{ .Int = 1 }, .value = .{ .Int = 10 } },
    };
    rec.append_entries = &entries;
    var cap = runtime.CaptureOutput.init(testing.allocator);
    defer cap.deinit();
    const args = [_]Value{.Unit};
    var ctx = CallCtx{ .args = &args, .out = cap.output(), .host = rec.host(), .allocator = testing.allocator };
    const r = try builders_build_map(&ctx);
    try testing.expect(r == .ok);
    defer freeListResult(r.ok);
    try testing.expect(r.ok == .Map);
    try testing.expect(!r.ok.Map.mutable);
    const g = r.ok.Map.entries.borrow();
    defer g.deinit();
    try testing.expectEqual(@as(usize, 1), g.get().pairs.items.len);
    try testing.expectEqual(@as(i32, 1), g.get().pairs.items[0].key.Int);
    try testing.expectEqual(@as(i32, 10), g.get().pairs.items[0].value.Int);
}

test "buildString returns the accumulated buffer" {
    var rec = RecordingHost.init(testing.allocator);
    defer rec.deinit();
    rec.append_bytes = "hello";
    var cap = runtime.CaptureOutput.init(testing.allocator);
    defer cap.deinit();
    const args = [_]Value{.Unit};
    var ctx = CallCtx{ .args = &args, .out = cap.output(), .host = rec.host(), .allocator = testing.allocator };
    const r = try builders_build_string(&ctx);
    try testing.expect(r == .ok);
    const g = r.ok.String.borrow();
    defer {
        g.deinit();
        r.ok.String.deinit();
    }
    try testing.expectEqualStrings("hello", g.get().bytes);
}

test "buildString rejects bad arity" {
    var rec = RecordingHost.init(testing.allocator);
    defer rec.deinit();
    var cap = runtime.CaptureOutput.init(testing.allocator);
    defer cap.deinit();
    const args = [_]Value{ .Unit, .Unit, .Unit };
    var ctx = CallCtx{ .args = &args, .out = cap.output(), .host = rec.host(), .allocator = testing.allocator };
    const r = try builders_build_string(&ctx);
    try testing.expect(r == .err);
    try testing.expect(r.err == .Arity);
}

test "buildList propagates a builder error" {
    var rec = RecordingHost.init(testing.allocator);
    defer rec.deinit();
    rec.fail_with = .Break;
    var cap = runtime.CaptureOutput.init(testing.allocator);
    defer cap.deinit();
    const args = [_]Value{.Unit};
    var ctx = CallCtx{ .args = &args, .out = cap.output(), .host = rec.host(), .allocator = testing.allocator };
    const r = try builders_build_list(&ctx);
    try testing.expect(r == .err);
    try testing.expect(r.err == .Break);
}

test "error throws IllegalStateException with the message string" {
    var rec = RecordingHost.init(testing.allocator);
    defer rec.deinit();
    var cap = runtime.CaptureOutput.init(testing.allocator);
    defer cap.deinit();
    const sref = try runtime.strInit(testing.allocator, "boom");
    defer sref.deinit();
    const args = [_]Value{.{ .String = sref }};
    var ctx = CallCtx{ .args = &args, .out = cap.output(), .host = rec.host(), .allocator = testing.allocator };
    const r = try contract_error(&ctx);
    try testing.expect(r == .err);
    try testing.expect(r.err == .Thrown);
    const exc = r.err.Thrown.Exception;
    defer freeException(exc);
    const fg = exc.fqn.borrow();
    defer fg.deinit();
    try testing.expectEqualStrings("kotlin.IllegalStateException", fg.get().bytes);
    const mg = exc.message.get().?.borrow();
    defer mg.deinit();
    try testing.expectEqualStrings("boom", mg.get().bytes);
}

test "error renders a non-string argument via display" {
    var rec = RecordingHost.init(testing.allocator);
    defer rec.deinit();
    var cap = runtime.CaptureOutput.init(testing.allocator);
    defer cap.deinit();
    const args = [_]Value{.{ .Int = 42 }};
    var ctx = CallCtx{ .args = &args, .out = cap.output(), .host = rec.host(), .allocator = testing.allocator };
    const r = try contract_error(&ctx);
    try testing.expect(r == .err);
    const exc = r.err.Thrown.Exception;
    defer freeException(exc);
    const mg = exc.message.get().?.borrow();
    defer mg.deinit();
    try testing.expectEqualStrings("42", mg.get().bytes);
}

test "TODO throws NotImplementedError with a message" {
    var rec = RecordingHost.init(testing.allocator);
    defer rec.deinit();
    var cap = runtime.CaptureOutput.init(testing.allocator);
    defer cap.deinit();
    const sref = try runtime.strInit(testing.allocator, "later");
    defer sref.deinit();
    const args = [_]Value{.{ .String = sref }};
    var ctx = CallCtx{ .args = &args, .out = cap.output(), .host = rec.host(), .allocator = testing.allocator };
    const r = try contract_todo(&ctx);
    try testing.expect(r == .err);
    const exc = r.err.Thrown.Exception;
    defer freeException(exc);
    const fg = exc.fqn.borrow();
    defer fg.deinit();
    try testing.expectEqualStrings("kotlin.NotImplementedError", fg.get().bytes);
    const mg = exc.message.get().?.borrow();
    defer mg.deinit();
    try testing.expectEqualStrings("An operation is not implemented: later", mg.get().bytes);
}

test "TODO without an argument uses the default message" {
    var rec = RecordingHost.init(testing.allocator);
    defer rec.deinit();
    var cap = runtime.CaptureOutput.init(testing.allocator);
    defer cap.deinit();
    var ctx = CallCtx{ .args = &.{}, .out = cap.output(), .host = rec.host(), .allocator = testing.allocator };
    const r = try contract_todo(&ctx);
    try testing.expect(r == .err);
    const exc = r.err.Thrown.Exception;
    defer freeException(exc);
    const mg = exc.message.get().?.borrow();
    defer mg.deinit();
    try testing.expectEqualStrings("An operation is not implemented.", mg.get().bytes);
}
