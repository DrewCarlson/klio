//! Env-gated dispatch tracing. Zero cost when unset: each gate parses once.
//!
//! `KLIO_TRACE_RESOLVE=<comma list of simple fn names, or *>`: a `[RESOLVE]` line per
//! dispatch decision.
//! `KLIO_TRACE_CHAIN=1`: the enclosing-`this` chain after a traced member dispatch.
//! `KLIO_TRACE_INVARIANTS=1`: an `[INVARIANT]` line per violation; the checks report,
//! never repair.
//! `KLIO_TRACE_PATH=1`: a `[PATH]` record per terminal dispatch, read by
//! `scripts/assert_single_path.py`.

const std = @import("std");

const runtime = @import("runtime");
const Value = runtime.Value;

const Filter = struct {
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
            .all = std.mem.find(u8, v, "*") != null,
            .raw = v,
        };
    } else {
        filter_state = .{ .present = false, .all = false, .raw = "" };
    }
    filter_done.store(true, .release);
}

/// Read env var `name` into `buf`, returning a subslice or null when unset; a longer
/// value is truncated.
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

/// With `KLIO_TRACE_CHAIN=1`, print the enclosing-`this` chain, closest receiver first.
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

/// Short receiver-kind label: an instance's class name, the variant tag for callable kinds,
/// else the simple name of `typeFqn` (`MutableList` vs `List`, `IntArray` vs `Array`).
/// The instance and class cases allocate; release with `freeLabel`.
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
            break :blk try std.fmt.allocPrint(allocator, "Class({s})", .{cg.get().fqn});
        },
        .Null => "Null",
        .IrClosure, .Intrinsic, .BoundMethod => @tagName(v),
        else => blk: {
            const fqn = v.typeFqn();
            break :blk if (std.mem.findScalarLast(u8, fqn, '.')) |i| fqn[i + 1 ..] else fqn;
        },
    };
}

/// Whether `recvLabel`'s label for `v` is heap-owned rather than a string literal.
fn labelOwned(v: Value) bool {
    return switch (v) {
        .Instance, .Class => true,
        else => false,
    };
}

/// Free a `recvLabel` result. A no-op for the static-literal variants.
pub fn freeLabel(allocator: std.mem.Allocator, v: Value, label: []const u8) void {
    if (labelOwned(v)) allocator.free(label);
}

var inv_inited = std.atomic.Value(bool).init(false);
var inv_done = std.atomic.Value(bool).init(false);
var inv_on: bool = false;

fn ensureInvariants() void {
    if (inv_done.load(.acquire)) return;
    if (inv_inited.swap(true, .acquire)) {
        while (!inv_done.load(.acquire)) std.atomic.spinLoopHint();
        return;
    }
    var ibuf: [64]u8 = undefined;
    if (readEnv("KLIO_TRACE_INVARIANTS", &ibuf)) |v| {
        inv_on = v.len != 0 and !std.mem.eql(u8, v, "0");
    } else inv_on = false;
    inv_done.store(true, .release);
}

pub fn invariantsEnabled() bool {
    ensureInvariants();
    return inv_on;
}

/// Emit one violation record, a stable space-separated key=value line:
/// `[INVARIANT] kind=<id> site=<site> <detail...>`. Gate with `invariantsEnabled`.
pub fn invariant(comptime detail_fmt: []const u8, args: anytype) void {
    std.debug.print("[INVARIANT] " ++ detail_fmt ++ "\n", args);
}

var path_inited = std.atomic.Value(bool).init(false);
var path_done = std.atomic.Value(bool).init(false);
var path_on: bool = false;

fn ensurePath() void {
    if (path_done.load(.acquire)) return;
    if (path_inited.swap(true, .acquire)) {
        while (!path_done.load(.acquire)) std.atomic.spinLoopHint();
        return;
    }
    var pbuf: [64]u8 = undefined;
    if (readEnv("KLIO_TRACE_PATH", &pbuf)) |v| {
        path_on = v.len != 0 and !std.mem.eql(u8, v, "0");
    } else path_on = false;
    path_done.store(true, .release);
}

pub fn pathEnabled() bool {
    ensurePath();
    return path_on;
}

/// Emit one dispatch-path record, a stable space-separated key=value line:
/// `[PATH] fn=<simple> recv=<label> argc=<n> args=<tags> decl=<fqn>#<fid> path=<tag>`.
pub fn path(comptime fmt: []const u8, args: anytype) void {
    std.debug.print("[PATH] " ++ fmt ++ "\n", args);
}

const testing = std.testing;
test {
    testing.refAllDecls(@This());
}

test "pathEnabled is total" {
    // The env cannot be controlled in-process, so assert only that the call is total.
    _ = pathEnabled();
}

test "path gate parse semantics" {
    // Empty and a literal "0" are off, anything else on, mirroring the invariants gate.
    // Exercised on the parse expression directly since the env is process-global.
    const parse = struct {
        fn on(v: []const u8) bool {
            return v.len != 0 and !std.mem.eql(u8, v, "0");
        }
    };
    try testing.expect(!parse.on(""));
    try testing.expect(!parse.on("0"));
    try testing.expect(parse.on("1"));
    try testing.expect(parse.on("yes"));
}

test "enabled is false when unset" {
    // The env cannot be controlled in-process, so assert only that the call is total.
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

    const str = try runtime.strInit(a, "hi");
    defer str.deinit();
    const str_val: Value = .{ .String = str };
    const str_label = try recvLabel(a, str_val);
    defer freeLabel(a, str_val, str_label);
    try testing.expectEqualStrings("String", str_label);
}
