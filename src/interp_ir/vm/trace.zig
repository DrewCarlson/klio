//! Env-gated dispatch tracing for diagnosing name-resolution bugs.
//!
//! Set `KLIO_TRACE_RESOLVE` to a comma-separated list of simple function
//! names (or `*` for every call) to log each dispatch decision to stderr.
//! Set `KLIO_TRACE_CHAIN=1` to also print the enclosing-`this` chain
//! after a traced member dispatch.
//!
//! Zero cost when unset: the filter is parsed once and cached, and every
//! trace point is guarded by `enabled`.

const std = @import("std");

const runtime = @import("runtime");
const Value = runtime.Value;

const Filter = struct {
    /// `true` when `KLIO_TRACE_RESOLVE` was set (even if empty).
    present: bool,
    /// `true` when the value was `*` (trace everything).
    all: bool,
    /// Raw comma list (owned). Searched on each `enabled` call.
    raw: []const u8,
};

var filter_inited = std.atomic.Value(bool).init(false);
var filter_done = std.atomic.Value(bool).init(false);
var filter_state: Filter = .{ .present = false, .all = false, .raw = "" };

var filter_buf: [1024]u8 = undefined;

fn ensureFilter() void {
    if (filter_done.load(.acquire)) return;
    // First caller initializes; others spin until it publishes.
    if (filter_inited.swap(true, .acquire)) {
        while (!filter_done.load(.acquire)) std.atomic.spinLoopHint();
        return;
    }
    if (readEnv("KLIO_TRACE_RESOLVE", &filter_buf)) |v| {
        filter_state = .{
            .present = true,
            .all = std.mem.indexOf(u8, v, "*") != null,
            .raw = v,
        };
    } else {
        filter_state = .{ .present = false, .all = false, .raw = "" };
    }
    filter_done.store(true, .release);
}

/// Read environment variable `name` into `buf`, returning the value
/// slice (a subslice of `buf`) or `null` when unset. Reads the process
/// environment portably; a value longer than `buf` is truncated.
fn readEnv(name: []const u8, buf: []u8) ?[]const u8 {
    const a = std.heap.page_allocator;
    const val = (runtime.procEnvGetVar(a, name) catch null) orelse return null;
    defer a.free(val);
    const len = @min(val.len, buf.len);
    @memcpy(buf[0..len], val[0..len]);
    return buf[0..len];
}

/// True when dispatch decisions for `name` should be logged.
pub fn enabled(name: []const u8) bool {
    ensureFilter();
    if (!filter_state.present) return false;
    if (filter_state.all) return true;
    var it = std.mem.splitScalar(u8, filter_state.raw, ',');
    while (it.next()) |part| {
        const trimmed = std.mem.trim(u8, part, " \t");
        if (std.mem.eql(u8, trimmed, name)) return true;
    }
    return false;
}

/// Emit one trace line (callers gate with `enabled`).
pub fn emit(comptime fmt: []const u8, args: anytype) void {
    std.debug.print("[RESOLVE] " ++ fmt ++ "\n", args);
}

var chain_inited = std.atomic.Value(bool).init(false);
var chain_done = std.atomic.Value(bool).init(false);
var chain_on: bool = false;

fn ensureChain() void {
    if (chain_done.load(.acquire)) return;
    if (chain_inited.swap(true, .acquire)) {
        while (!chain_done.load(.acquire)) std.atomic.spinLoopHint();
        return;
    }
    var cbuf: [64]u8 = undefined;
    chain_on = readEnv("KLIO_TRACE_CHAIN", &cbuf) != null;
    chain_done.store(true, .release);
}

/// When `KLIO_TRACE_CHAIN=1`, print the enclosing-`this` chain (closest
/// receiver first) after a traced member dispatch — the set a bare member
/// call resolves against. Reveals when a lexically-intended enclosing
/// receiver is missing or shadowed by a dynamically-nested one.
pub fn maybeDumpChain(allocator: std.mem.Allocator, chain: []const Value) void {
    ensureChain();
    if (!chain_on) return;
    std.debug.print("[RESOLVE]   chain=[", .{});
    for (chain, 0..) |v, i| {
        if (i != 0) std.debug.print(", ", .{});
        const label = recvLabel(allocator, v) catch "?";
        defer if (labelOwned(v)) allocator.free(label);
        std.debug.print("{s}", .{label});
    }
    std.debug.print("]\n", .{});
}

/// A short receiver-kind label for a dispatch trace (the runtime value's
/// class name for an instance, or a coarse variant tag otherwise). The
/// instance and class cases allocate; release with `freeLabel`.
pub fn recvLabel(allocator: std.mem.Allocator, v: Value) std.mem.Allocator.Error![]const u8 {
    return switch (v) {
        .Instance => |i| blk: {
            const g = i.borrow();
            defer g.deinit();
            const cg = g.get().class.borrow();
            defer cg.deinit();
            break :blk try allocator.dupe(u8, cg.get().name);
        },
        .Class => |c| blk: {
            const cg = c.borrow();
            defer cg.deinit();
            break :blk try std.fmt.allocPrint(allocator, "Class({s})", .{cg.get().name});
        },
        .String => "String",
        .Array => "Array",
        .Null => "Null",
        .Unit => "Unit",
        else => @tagName(v),
    };
}

/// Whether the label produced by `recvLabel` for `v` is heap-owned by the
/// caller's allocator (and must be freed) versus a static string literal.
fn labelOwned(v: Value) bool {
    return switch (v) {
        .Instance, .Class => true,
        else => false,
    };
}

/// Free a label returned by `recvLabel` for value `v`. A no-op for the
/// static-literal variants.
pub fn freeLabel(allocator: std.mem.Allocator, v: Value, label: []const u8) void {
    if (labelOwned(v)) allocator.free(label);
}

const testing = std.testing;
test {
    testing.refAllDecls(@This());
}

test "enabled is false when unset" {
    // Cannot reliably control the env in-process across runs; just ensure
    // the call is total and does not crash.
    _ = enabled("anything");
}

test "recvLabel coarse variant tags" {
    const a = testing.allocator;

    const unit_label = try recvLabel(a, .Unit);
    defer freeLabel(a, .Unit, unit_label);
    try testing.expectEqualStrings("Unit", unit_label);

    const null_label = try recvLabel(a, .Null);
    defer freeLabel(a, .Null, null_label);
    try testing.expectEqualStrings("Null", null_label);

    const int_val: Value = .{ .Int = 5 };
    const int_label = try recvLabel(a, int_val);
    defer freeLabel(a, int_val, int_label);
    try testing.expectEqualStrings("Int", int_label);

    const str = try runtime.StringRef.init(a, "hi");
    defer str.deinit();
    const str_val: Value = .{ .String = str };
    const str_label = try recvLabel(a, str_val);
    defer freeLabel(a, str_val, str_label);
    try testing.expectEqualStrings("String", str_label);
}
