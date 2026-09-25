//! Small value builders and error conversions the host's members share.

const std = @import("std");

const ir = @import("ir");
const runtime = @import("runtime");

const Allocator = std.mem.Allocator;
const Value = runtime.Value;
const ObjRef = runtime.ObjRef;
const RuntimeError = runtime.RuntimeError;
const EvalError = ir.eval.EvalError;

pub fn boolVal(b: bool) Value {
    return .{ .Bool = b };
}

pub fn strVal(allocator: Allocator, s: []const u8) Allocator.Error!Value {
    return .{ .String = try runtime.strInit(allocator, s) };
}

pub fn typeErr(allocator: Allocator, comptime fmt: []const u8, args: anytype) Allocator.Error!EvalError {
    return .{ .Type = try std.fmt.allocPrint(allocator, fmt, args) };
}

/// A host exception of class `fqn`, thrown.
pub fn throwExc(allocator: Allocator, fqn: []const u8, message: ?[]const u8) Allocator.Error!EvalError {
    return .{ .Throw = try Value.newException(allocator, .{
        .fqn = try runtime.strInit(allocator, fqn),
        .message = .from(if (message) |m| try runtime.strInit(allocator, m) else null),
        .cause = null,
    }) };
}

/// A native's error as the evaluator carries it.
pub fn mapRuntimeError(allocator: Allocator, e: RuntimeError) Allocator.Error!EvalError {
    return switch (e) {
        .Thrown => |v| .{ .Throw = v },
        .Return => |v| .{ .NonLocalReturn = v },
        .Suspend => |wake| blk: {
            const ss = try allocator.create(ir.eval.SuspendState);
            ss.* = .{ .token = 0, .frames = .empty, .wake_in_millis = wake, .pending_resume_reg = null };
            break :blk .{ .Suspended = ss };
        },
        .CalleeFailed => |m| .{ .CalleeFailed = m },
        // Each message-carrying variant keeps its text; collapsing to the tag
        // name would report "IR eval: Type" instead of the real diagnostic.
        .Type => |s| .{ .Type = s },
        .Unbound => |s| .{ .Unbound = s },
        .Unimplemented => |s| .{ .Unimplemented = s },
        .Arity => |s| .{ .Arity = s },
        else => |other| try typeErr(allocator, "unexpected intrinsic result: {s}", .{@tagName(other)}),
    };
}

pub fn listOf(allocator: Allocator, items: std.ArrayList(Value), mutable: bool) Allocator.Error!Value {
    return try Value.newList(allocator, .{
        .items = try ObjRef(std.ArrayList(Value)).init(allocator, items),
        .mutable = mutable,
        .enum_entries = false,
        .backing = null,
    });
}

pub fn cloneItemsList(allocator: Allocator, src: runtime.ValueList) Allocator.Error!std.ArrayList(Value) {
    const g = src.borrow();
    defer g.deinit();
    var out: std.ArrayList(Value) = .empty;
    try out.appendSlice(allocator, g.get().items);
    // Owned copy: every wrapper built from this list takes one reference per
    // element, so retain each; the source keeps its own. No-op under the arena.
    if (runtime.reclaimEnabled()) for (out.items) |e| e.retain();
    return out;
}

pub fn simpleName(name: []const u8) []const u8 {
    if (std.mem.findScalarLast(u8, name, '.')) |i| return name[i + 1 ..];
    return name;
}

/// The name `toString` and `KClass.simpleName` report: a nested class lifts to
/// a flat `Outer$Data` but Kotlin shows `Data`, and `$` cannot occur in a
/// source class name, so the segment after the last `$` is that name.
pub fn classDisplayName(name: []const u8) []const u8 {
    var n = name;
    if (std.mem.findScalarLast(u8, n, '$')) |i| n = n[i + 1 ..];
    return simpleName(n);
}

/// `KClass.simpleName` of a runtime class name: a nested class is stored lifted
/// as `Outer$Inner` and a local class under the mangle `Name$lc<fn>`.
pub fn classSimpleName(name: []const u8) []const u8 {
    var n = name;
    if (std.mem.find(u8, n, "$lc")) |i| n = n[0..i];
    if (std.mem.findLastAny(u8, n, "$.")) |i| {
        if (i + 1 < n.len) n = n[i + 1 ..];
    }
    return n;
}

pub fn isIteratorNext(name: []const u8) bool {
    const ns = [_][]const u8{ "next", "nextInt", "nextLong", "nextChar", "nextByte", "nextShort", "nextDouble", "nextFloat", "nextBoolean" };
    for (ns) |n| {
        if (std.mem.eql(u8, n, name)) return true;
    }
    return false;
}

/// Generation stamp for every process-global and thread-local dispatch cache.
/// A driver running many programs per process frees each program's module and
/// arena, and the next program reuses those pointer identities, so an entry
/// keyed on them would replay the earlier resolution or call into freed IR.
/// Such drivers bump the generation per program; older stamps never hit.
pub var dispatch_cache_gen: std.atomic.Value(u32) = std.atomic.Value(u32).init(1);

pub fn dispatchCacheGen() u32 {
    return dispatch_cache_gen.load(.monotonic);
}

pub fn bumpDispatchCacheGen() void {
    _ = dispatch_cache_gen.fetchAdd(1, .monotonic);
}
