//! `klio.bundle.*` intrinsics: the embedded-resource surface a bundled
//! program reads through `klio.bundle.Resources`, plus
//! `kotlin.system.exitProcess`.
//!
//! Each intrinsic is a `fn(*CallCtx) !EvalResult`; the Kotlin side lives
//! in the `klio.bundle` pack (`kotlin-klio/klio-bundle`), whose thin
//! object methods delegate to these `__klio_bundle_*` functions.

const std = @import("std");
const runtime = @import("runtime");

const bundle_resources = @import("../bundle_resources.zig");

const Allocator = std.mem.Allocator;
const Value = runtime.Value;
const EvalResult = runtime.EvalResult;
const CallCtx = runtime.CallCtx;
const StringRef = runtime.StringRef;
const ObjRef = runtime.ObjRef;
const PrimBuf = runtime.PrimBuf;
const ValueList = runtime.ValueList;

fn ok(v: Value) EvalResult {
    return .{ .ok = v };
}

fn makeException(allocator: Allocator, fqn: []const u8, message: []const u8) Allocator.Error!Value {
    const fqn_ref = try runtime.strInitOwned(allocator, try allocator.dupe(u8, fqn));
    const msg_ref: ?StringRef = try runtime.strInit(allocator, message);
    return try Value.newException(allocator, .{ .fqn = fqn_ref, .message = .from(msg_ref), .cause = null });
}

fn thrown(allocator: Allocator, fqn: []const u8, message: []const u8) Allocator.Error!EvalResult {
    return .{ .err = .{ .Thrown = try makeException(allocator, fqn, message) } };
}

fn pathArg(ctx: *CallCtx) ?[]const u8 {
    if (ctx.args.len < 1 or ctx.args[ctx.args.len - 1] != .String) return null;
    const g = ctx.args[ctx.args.len - 1].String.borrow();
    defer g.deinit();
    return g.get().bytes;
}

fn resourceBytes(ctx: *CallCtx, path: []const u8) Allocator.Error!union(enum) { bytes: []const u8, err: EvalResult } {
    if (!bundle_resources.isActive()) {
        return .{ .err = try thrown(ctx.allocator, "kotlin.IllegalStateException", "no resources are bundled with this program") };
    }
    const entry = bundle_resources.find(path) orelse {
        const msg = try std.fmt.allocPrint(ctx.allocator, "no bundled resource at `{s}`", .{path});
        defer if (runtime.freeScratch()) ctx.allocator.free(msg);
        return .{ .err = try thrown(ctx.allocator, "kotlin.IllegalArgumentException", msg) };
    };
    const bytes = (try bundle_resources.read(ctx.allocator, entry)) orelse {
        return .{ .err = try thrown(ctx.allocator, "kotlin.IllegalStateException", "bundled resource is corrupt; rebundle") };
    };
    return .{ .bytes = bytes };
}

/// `klio.bundle.__klio_bundle_readBytes(path: String): ByteArray`
pub fn bundle_read_bytes(ctx: *CallCtx) Allocator.Error!EvalResult {
    const path = pathArg(ctx) orelse return .{ .err = .{ .Arity = "readBytes expects a String path" } };
    const res = try resourceBytes(ctx, path);
    switch (res) {
        .err => |e| return e,
        .bytes => |bytes| {
            var pb = PrimBuf{ .kind = .Byte };
            try pb.bytes.appendSlice(ctx.allocator, bytes);
            return ok(.{ .Array = runtime.ArrayData.scalars(try ObjRef(PrimBuf).initOwned(ctx.allocator, pb), .Byte) });
        },
    }
}

/// `klio.bundle.__klio_bundle_readText(path: String): String`
pub fn bundle_read_text(ctx: *CallCtx) Allocator.Error!EvalResult {
    const path = pathArg(ctx) orelse return .{ .err = .{ .Arity = "readText expects a String path" } };
    const res = try resourceBytes(ctx, path);
    switch (res) {
        .err => |e| return e,
        .bytes => |bytes| return ok(.{ .String = try runtime.strInit(ctx.allocator, bytes) }),
    }
}

/// `klio.bundle.__klio_bundle_exists(path: String): Boolean`
pub fn bundle_exists(ctx: *CallCtx) Allocator.Error!EvalResult {
    const path = pathArg(ctx) orelse return .{ .err = .{ .Arity = "exists expects a String path" } };
    return ok(.{ .Bool = bundle_resources.isActive() and bundle_resources.find(path) != null });
}

/// `klio.bundle.__klio_bundle_list(): List<String>`
pub fn bundle_list(ctx: *CallCtx) Allocator.Error!EvalResult {
    const a = ctx.allocator;
    var items: std.ArrayList(Value) = .empty;
    errdefer items.deinit(a);
    for (bundle_resources.all()) |e| {
        try items.append(a, .{ .String = try runtime.strInit(a, e.mount) });
    }
    const items_ref = try ValueList.init(a, items);
    return ok(try Value.newList(a, .{ .items = items_ref, .mutable = false, .enum_entries = false, .backing = null }));
}

/// `kotlin.system.exitProcess(status: Int): Nothing` — terminates the
/// process immediately with `status`, like the JVM's `System.exit`.
/// Program output is written unbuffered, so nothing is lost.
pub fn system_exit_process(ctx: *CallCtx) Allocator.Error!EvalResult {
    const status: u8 = if (ctx.args.len >= 1) switch (ctx.args[ctx.args.len - 1]) {
        .Int => |i| @truncate(@as(u32, @bitCast(i))),
        .Long => |i| @truncate(@as(u64, @bitCast(i))),
        else => 0,
    } else 0;
    std.process.exit(status);
}

test {
    std.testing.refAllDecls(@This());
}
